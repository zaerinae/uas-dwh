-- phpMyAdmin SQL Dump
-- version 4.8.3
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Waktu pembuatan: 10 Jan 2021 pada 13.50
-- Versi server: 10.1.37-MariaDB
-- Versi PHP: 7.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET AUTOCOMMIT = 0;
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `sakila`
--

DELIMITER $$
--
-- Prosedur
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `film_in_stock` (IN `p_film_id` INT, IN `p_store_id` INT, OUT `p_film_count` INT)  READS SQL DATA
BEGIN
     SELECT inventory_id
     FROM inventory
     WHERE film_id = p_film_id
     AND store_id = p_store_id
     AND inventory_in_stock(inventory_id);

     SELECT COUNT(*)
     FROM inventory
     WHERE film_id = p_film_id
     AND store_id = p_store_id
     AND inventory_in_stock(inventory_id)
     INTO p_film_count;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `film_not_in_stock` (IN `p_film_id` INT, IN `p_store_id` INT, OUT `p_film_count` INT)  READS SQL DATA
BEGIN
     SELECT inventory_id
     FROM inventory
     WHERE film_id = p_film_id
     AND store_id = p_store_id
     AND NOT inventory_in_stock(inventory_id);

     SELECT COUNT(*)
     FROM inventory
     WHERE film_id = p_film_id
     AND store_id = p_store_id
     AND NOT inventory_in_stock(inventory_id)
     INTO p_film_count;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `rewards_report` (IN `min_monthly_purchases` TINYINT UNSIGNED, IN `min_dollar_amount_purchased` DECIMAL(10,2), OUT `count_rewardees` INT)  READS SQL DATA
    COMMENT 'Provides a customizable report on best customers'
proc: BEGIN

    DECLARE last_month_start DATE;
    DECLARE last_month_end DATE;

    /* Some sanity checks... */
    IF min_monthly_purchases = 0 THEN
        SELECT 'Minimum monthly purchases parameter must be > 0';
        LEAVE proc;
    END IF;
    IF min_dollar_amount_purchased = 0.00 THEN
        SELECT 'Minimum monthly dollar amount purchased parameter must be > $0.00';
        LEAVE proc;
    END IF;

    /* Determine start and end time periods */
    SET last_month_start = DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH);
    SET last_month_start = STR_TO_DATE(CONCAT(YEAR(last_month_start),'-',MONTH(last_month_start),'-01'),'%Y-%m-%d');
    SET last_month_end = LAST_DAY(last_month_start);

    /*
        Create a temporary storage area for
        Customer IDs.
    */
    CREATE TEMPORARY TABLE tmpCustomer (customer_id SMALLINT UNSIGNED NOT NULL PRIMARY KEY);

    /*
        Find all customers meeting the
        monthly purchase requirements
    */
    INSERT INTO tmpCustomer (customer_id)
    SELECT p.customer_id
    FROM payment AS p
    WHERE DATE(p.payment_date) BETWEEN last_month_start AND last_month_end
    GROUP BY customer_id
    HAVING SUM(p.amount) > min_dollar_amount_purchased
    AND COUNT(customer_id) > min_monthly_purchases;

    /* Populate OUT parameter with count of found customers */
    SELECT COUNT(*) FROM tmpCustomer INTO count_rewardees;

    /*
        Output ALL customer information of matching rewardees.
        Customize output as needed.
    */
    SELECT c.*
    FROM tmpCustomer AS t
    INNER JOIN customer AS c ON t.customer_id = c.customer_id;

    /* Clean up */
    DROP TABLE tmpCustomer;
END$$

--
-- Fungsi
--
CREATE DEFINER=`root`@`localhost` FUNCTION `get_customer_balance` (`p_customer_id` INT, `p_effective_date` DATETIME) RETURNS DECIMAL(5,2) READS SQL DATA
    DETERMINISTIC
BEGIN

       #OK, WE NEED TO CALCULATE THE CURRENT BALANCE GIVEN A CUSTOMER_ID AND A DATE
       #THAT WE WANT THE BALANCE TO BE EFFECTIVE FOR. THE BALANCE IS:
       #   1) RENTAL FEES FOR ALL PREVIOUS RENTALS
       #   2) ONE DOLLAR FOR EVERY DAY THE PREVIOUS RENTALS ARE OVERDUE
       #   3) IF A FILM IS MORE THAN RENTAL_DURATION * 2 OVERDUE, CHARGE THE REPLACEMENT_COST
       #   4) SUBTRACT ALL PAYMENTS MADE BEFORE THE DATE SPECIFIED

  DECLARE v_rentfees DECIMAL(5,2); #FEES PAID TO RENT THE VIDEOS INITIALLY
  DECLARE v_overfees INTEGER;      #LATE FEES FOR PRIOR RENTALS
  DECLARE v_payments DECIMAL(5,2); #SUM OF PAYMENTS MADE PREVIOUSLY

  SELECT IFNULL(SUM(film.rental_rate),0) INTO v_rentfees
    FROM film, inventory, rental
    WHERE film.film_id = inventory.film_id
      AND inventory.inventory_id = rental.inventory_id
      AND rental.rental_date <= p_effective_date
      AND rental.customer_id = p_customer_id;

  SELECT IFNULL(SUM(IF((TO_DAYS(rental.return_date) - TO_DAYS(rental.rental_date)) > film.rental_duration,
        ((TO_DAYS(rental.return_date) - TO_DAYS(rental.rental_date)) - film.rental_duration),0)),0) INTO v_overfees
    FROM rental, inventory, film
    WHERE film.film_id = inventory.film_id
      AND inventory.inventory_id = rental.inventory_id
      AND rental.rental_date <= p_effective_date
      AND rental.customer_id = p_customer_id;


  SELECT IFNULL(SUM(payment.amount),0) INTO v_payments
    FROM payment

    WHERE payment.payment_date <= p_effective_date
    AND payment.customer_id = p_customer_id;

  RETURN v_rentfees + v_overfees - v_payments;
END$$

CREATE DEFINER=`root`@`localhost` FUNCTION `inventory_held_by_customer` (`p_inventory_id` INT) RETURNS INT(11) READS SQL DATA
BEGIN
  DECLARE v_customer_id INT;
  DECLARE EXIT HANDLER FOR NOT FOUND RETURN NULL;

  SELECT customer_id INTO v_customer_id
  FROM rental
  WHERE return_date IS NULL
  AND inventory_id = p_inventory_id;

  RETURN v_customer_id;
END$$

CREATE DEFINER=`root`@`localhost` FUNCTION `inventory_in_stock` (`p_inventory_id` INT) RETURNS TINYINT(1) READS SQL DATA
BEGIN
    DECLARE v_rentals INT;
    DECLARE v_out     INT;

    #AN ITEM IS IN-STOCK IF THERE ARE EITHER NO ROWS IN THE rental TABLE
    #FOR THE ITEM OR ALL ROWS HAVE return_date POPULATED

    SELECT COUNT(*) INTO v_rentals
    FROM rental
    WHERE inventory_id = p_inventory_id;

    IF v_rentals = 0 THEN
      RETURN TRUE;
    END IF;

    SELECT COUNT(rental_id) INTO v_out
    FROM inventory LEFT JOIN rental USING(inventory_id)
    WHERE inventory.inventory_id = p_inventory_id
    AND rental.return_date IS NULL;

    IF v_out > 0 THEN
      RETURN FALSE;
    ELSE
      RETURN TRUE;
    END IF;
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Struktur dari tabel `actor`
--

CREATE TABLE `actor` (
  `actor_id` smallint(5) UNSIGNED NOT NULL,
  `first_name` varchar(45) NOT NULL,
  `last_name` varchar(45) NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

--
-- Dumping data untuk tabel `actor`
--

INSERT INTO `actor` (`actor_id`, `first_name`, `last_name`, `last_update`) VALUES
(1, 'PENELOPE', 'GUINESS', '2006-02-14 21:34:33'),
(2, 'NICK', 'WAHLBERG', '2006-02-14 21:34:33'),
(3, 'ED', 'CHASE', '2006-02-14 21:34:33'),
(4, 'JENNIFER', 'DAVIS', '2006-02-14 21:34:33'),
(5, 'JOHNNY', 'LOLLOBRIGIDA', '2006-02-14 21:34:33'),
(6, 'BETTE', 'NICHOLSON', '2006-02-14 21:34:33'),
(7, 'GRACE', 'MOSTEL', '2006-02-14 21:34:33'),
(8, 'MATTHEW', 'JOHANSSON', '2006-02-14 21:34:33'),
(9, 'JOE', 'SWANK', '2006-02-14 21:34:33'),
(10, 'CHRISTIAN', 'GABLE', '2006-02-14 21:34:33'),
(11, 'ZERO', 'CAGE', '2006-02-14 21:34:33'),
(12, 'KARL', 'BERRY', '2006-02-14 21:34:33'),
(13, 'UMA', 'WOOD', '2006-02-14 21:34:33'),
(14, 'VIVIEN', 'BERGEN', '2006-02-14 21:34:33'),
(15, 'CUBA', 'OLIVIER', '2006-02-14 21:34:33'),
(16, 'FRED', 'COSTNER', '2006-02-14 21:34:33'),
(17, 'HELEN', 'VOIGHT', '2006-02-14 21:34:33'),
(18, 'DAN', 'TORN', '2006-02-14 21:34:33'),
(19, 'BOB', 'FAWCETT', '2006-02-14 21:34:33'),
(20, 'LUCILLE', 'TRACY', '2006-02-14 21:34:33'),
(21, 'KIRSTEN', 'PALTROW', '2006-02-14 21:34:33'),
(22, 'ELVIS', 'MARX', '2006-02-14 21:34:33'),
(23, 'SANDRA', 'KILMER', '2006-02-14 21:34:33'),
(24, 'CAMERON', 'STREEP', '2006-02-14 21:34:33'),
(25, 'KEVIN', 'BLOOM', '2006-02-14 21:34:33'),
(26, 'RIP', 'CRAWFORD', '2006-02-14 21:34:33'),
(27, 'JULIA', 'MCQUEEN', '2006-02-14 21:34:33'),
(28, 'WOODY', 'HOFFMAN', '2006-02-14 21:34:33'),
(29, 'ALEC', 'WAYNE', '2006-02-14 21:34:33'),
(30, 'SANDRA', 'PECK', '2006-02-14 21:34:33'),
(31, 'SISSY', 'SOBIESKI', '2006-02-14 21:34:33'),
(32, 'TIM', 'HACKMAN', '2006-02-14 21:34:33'),
(33, 'MILLA', 'PECK', '2006-02-14 21:34:33'),
(34, 'AUDREY', 'OLIVIER', '2006-02-14 21:34:33'),
(35, 'JUDY', 'DEAN', '2006-02-14 21:34:33'),
(36, 'BURT', 'DUKAKIS', '2006-02-14 21:34:33'),
(37, 'VAL', 'BOLGER', '2006-02-14 21:34:33'),
(38, 'TOM', 'MCKELLEN', '2006-02-14 21:34:33'),
(39, 'GOLDIE', 'BRODY', '2006-02-14 21:34:33'),
(40, 'JOHNNY', 'CAGE', '2006-02-14 21:34:33'),
(41, 'JODIE', 'DEGENERES', '2006-02-14 21:34:33'),
(42, 'TOM', 'MIRANDA', '2006-02-14 21:34:33'),
(43, 'KIRK', 'JOVOVICH', '2006-02-14 21:34:33'),
(44, 'NICK', 'STALLONE', '2006-02-14 21:34:33'),
(45, 'REESE', 'KILMER', '2006-02-14 21:34:33'),
(46, 'PARKER', 'GOLDBERG', '2006-02-14 21:34:33'),
(47, 'JULIA', 'BARRYMORE', '2006-02-14 21:34:33'),
(48, 'FRANCES', 'DAY-LEWIS', '2006-02-14 21:34:33'),
(49, 'ANNE', 'CRONYN', '2006-02-14 21:34:33'),
(50, 'NATALIE', 'HOPKINS', '2006-02-14 21:34:33'),
(51, 'GARY', 'PHOENIX', '2006-02-14 21:34:33'),
(52, 'CARMEN', 'HUNT', '2006-02-14 21:34:33'),
(53, 'MENA', 'TEMPLE', '2006-02-14 21:34:33'),
(54, 'PENELOPE', 'PINKETT', '2006-02-14 21:34:33'),
(55, 'FAY', 'KILMER', '2006-02-14 21:34:33'),
(56, 'DAN', 'HARRIS', '2006-02-14 21:34:33'),
(57, 'JUDE', 'CRUISE', '2006-02-14 21:34:33'),
(58, 'CHRISTIAN', 'AKROYD', '2006-02-14 21:34:33'),
(59, 'DUSTIN', 'TAUTOU', '2006-02-14 21:34:33'),
(60, 'HENRY', 'BERRY', '2006-02-14 21:34:33'),
(61, 'CHRISTIAN', 'NEESON', '2006-02-14 21:34:33'),
(62, 'JAYNE', 'NEESON', '2006-02-14 21:34:33'),
(63, 'CAMERON', 'WRAY', '2006-02-14 21:34:33'),
(64, 'RAY', 'JOHANSSON', '2006-02-14 21:34:33'),
(65, 'ANGELA', 'HUDSON', '2006-02-14 21:34:33'),
(66, 'MARY', 'TANDY', '2006-02-14 21:34:33'),
(67, 'JESSICA', 'BAILEY', '2006-02-14 21:34:33'),
(68, 'RIP', 'WINSLET', '2006-02-14 21:34:33'),
(69, 'KENNETH', 'PALTROW', '2006-02-14 21:34:33'),
(70, 'MICHELLE', 'MCCONAUGHEY', '2006-02-14 21:34:33'),
(71, 'ADAM', 'GRANT', '2006-02-14 21:34:33'),
(72, 'SEAN', 'WILLIAMS', '2006-02-14 21:34:33'),
(73, 'GARY', 'PENN', '2006-02-14 21:34:33'),
(74, 'MILLA', 'KEITEL', '2006-02-14 21:34:33'),
(75, 'BURT', 'POSEY', '2006-02-14 21:34:33'),
(76, 'ANGELINA', 'ASTAIRE', '2006-02-14 21:34:33'),
(77, 'CARY', 'MCCONAUGHEY', '2006-02-14 21:34:33'),
(78, 'GROUCHO', 'SINATRA', '2006-02-14 21:34:33'),
(79, 'MAE', 'HOFFMAN', '2006-02-14 21:34:33'),
(80, 'RALPH', 'CRUZ', '2006-02-14 21:34:33'),
(81, 'SCARLETT', 'DAMON', '2006-02-14 21:34:33'),
(82, 'WOODY', 'JOLIE', '2006-02-14 21:34:33'),
(83, 'BEN', 'WILLIS', '2006-02-14 21:34:33'),
(84, 'JAMES', 'PITT', '2006-02-14 21:34:33'),
(85, 'MINNIE', 'ZELLWEGER', '2006-02-14 21:34:33'),
(86, 'GREG', 'CHAPLIN', '2006-02-14 21:34:33'),
(87, 'SPENCER', 'PECK', '2006-02-14 21:34:33'),
(88, 'KENNETH', 'PESCI', '2006-02-14 21:34:33'),
(89, 'CHARLIZE', 'DENCH', '2006-02-14 21:34:33'),
(90, 'SEAN', 'GUINESS', '2006-02-14 21:34:33'),
(91, 'CHRISTOPHER', 'BERRY', '2006-02-14 21:34:33'),
(92, 'KIRSTEN', 'AKROYD', '2006-02-14 21:34:33'),
(93, 'ELLEN', 'PRESLEY', '2006-02-14 21:34:33'),
(94, 'KENNETH', 'TORN', '2006-02-14 21:34:33'),
(95, 'DARYL', 'WAHLBERG', '2006-02-14 21:34:33'),
(96, 'GENE', 'WILLIS', '2006-02-14 21:34:33'),
(97, 'MEG', 'HAWKE', '2006-02-14 21:34:33'),
(98, 'CHRIS', 'BRIDGES', '2006-02-14 21:34:33'),
(99, 'JIM', 'MOSTEL', '2006-02-14 21:34:33'),
(100, 'SPENCER', 'DEPP', '2006-02-14 21:34:33'),
(101, 'SUSAN', 'DAVIS', '2006-02-14 21:34:33'),
(102, 'WALTER', 'TORN', '2006-02-14 21:34:33'),
(103, 'MATTHEW', 'LEIGH', '2006-02-14 21:34:33'),
(104, 'PENELOPE', 'CRONYN', '2006-02-14 21:34:33'),
(105, 'SIDNEY', 'CROWE', '2006-02-14 21:34:33'),
(106, 'GROUCHO', 'DUNST', '2006-02-14 21:34:33'),
(107, 'GINA', 'DEGENERES', '2006-02-14 21:34:33'),
(108, 'WARREN', 'NOLTE', '2006-02-14 21:34:33'),
(109, 'SYLVESTER', 'DERN', '2006-02-14 21:34:33'),
(110, 'SUSAN', 'DAVIS', '2006-02-14 21:34:33'),
(111, 'CAMERON', 'ZELLWEGER', '2006-02-14 21:34:33'),
(112, 'RUSSELL', 'BACALL', '2006-02-14 21:34:33'),
(113, 'MORGAN', 'HOPKINS', '2006-02-14 21:34:33'),
(114, 'MORGAN', 'MCDORMAND', '2006-02-14 21:34:33'),
(115, 'HARRISON', 'BALE', '2006-02-14 21:34:33'),
(116, 'DAN', 'STREEP', '2006-02-14 21:34:33'),
(117, 'RENEE', 'TRACY', '2006-02-14 21:34:33'),
(118, 'CUBA', 'ALLEN', '2006-02-14 21:34:33'),
(119, 'WARREN', 'JACKMAN', '2006-02-14 21:34:33'),
(120, 'PENELOPE', 'MONROE', '2006-02-14 21:34:33'),
(121, 'LIZA', 'BERGMAN', '2006-02-14 21:34:33'),
(122, 'SALMA', 'NOLTE', '2006-02-14 21:34:33'),
(123, 'JULIANNE', 'DENCH', '2006-02-14 21:34:33'),
(124, 'SCARLETT', 'BENING', '2006-02-14 21:34:33'),
(125, 'ALBERT', 'NOLTE', '2006-02-14 21:34:33'),
(126, 'FRANCES', 'TOMEI', '2006-02-14 21:34:33'),
(127, 'KEVIN', 'GARLAND', '2006-02-14 21:34:33'),
(128, 'CATE', 'MCQUEEN', '2006-02-14 21:34:33'),
(129, 'DARYL', 'CRAWFORD', '2006-02-14 21:34:33'),
(130, 'GRETA', 'KEITEL', '2006-02-14 21:34:33'),
(131, 'JANE', 'JACKMAN', '2006-02-14 21:34:33'),
(132, 'ADAM', 'HOPPER', '2006-02-14 21:34:33'),
(133, 'RICHARD', 'PENN', '2006-02-14 21:34:33'),
(134, 'GENE', 'HOPKINS', '2006-02-14 21:34:33'),
(135, 'RITA', 'REYNOLDS', '2006-02-14 21:34:33'),
(136, 'ED', 'MANSFIELD', '2006-02-14 21:34:33'),
(137, 'MORGAN', 'WILLIAMS', '2006-02-14 21:34:33'),
(138, 'LUCILLE', 'DEE', '2006-02-14 21:34:33'),
(139, 'EWAN', 'GOODING', '2006-02-14 21:34:33'),
(140, 'WHOOPI', 'HURT', '2006-02-14 21:34:33'),
(141, 'CATE', 'HARRIS', '2006-02-14 21:34:33'),
(142, 'JADA', 'RYDER', '2006-02-14 21:34:33'),
(143, 'RIVER', 'DEAN', '2006-02-14 21:34:33'),
(144, 'ANGELA', 'WITHERSPOON', '2006-02-14 21:34:33'),
(145, 'KIM', 'ALLEN', '2006-02-14 21:34:33'),
(146, 'ALBERT', 'JOHANSSON', '2006-02-14 21:34:33'),
(147, 'FAY', 'WINSLET', '2006-02-14 21:34:33'),
(148, 'EMILY', 'DEE', '2006-02-14 21:34:33'),
(149, 'RUSSELL', 'TEMPLE', '2006-02-14 21:34:33'),
(150, 'JAYNE', 'NOLTE', '2006-02-14 21:34:33'),
(151, 'GEOFFREY', 'HESTON', '2006-02-14 21:34:33'),
(152, 'BEN', 'HARRIS', '2006-02-14 21:34:33'),
(153, 'MINNIE', 'KILMER', '2006-02-14 21:34:33'),
(154, 'MERYL', 'GIBSON', '2006-02-14 21:34:33'),
(155, 'IAN', 'TANDY', '2006-02-14 21:34:33'),
(156, 'FAY', 'WOOD', '2006-02-14 21:34:33'),
(157, 'GRETA', 'MALDEN', '2006-02-14 21:34:33'),
(158, 'VIVIEN', 'BASINGER', '2006-02-14 21:34:33'),
(159, 'LAURA', 'BRODY', '2006-02-14 21:34:33'),
(160, 'CHRIS', 'DEPP', '2006-02-14 21:34:33'),
(161, 'HARVEY', 'HOPE', '2006-02-14 21:34:33'),
(162, 'OPRAH', 'KILMER', '2006-02-14 21:34:33'),
(163, 'CHRISTOPHER', 'WEST', '2006-02-14 21:34:33'),
(164, 'HUMPHREY', 'WILLIS', '2006-02-14 21:34:33'),
(165, 'AL', 'GARLAND', '2006-02-14 21:34:33'),
(166, 'NICK', 'DEGENERES', '2006-02-14 21:34:33'),
(167, 'LAURENCE', 'BULLOCK', '2006-02-14 21:34:33'),
(168, 'WILL', 'WILSON', '2006-02-14 21:34:33'),
(169, 'KENNETH', 'HOFFMAN', '2006-02-14 21:34:33'),
(170, 'MENA', 'HOPPER', '2006-02-14 21:34:33'),
(171, 'OLYMPIA', 'PFEIFFER', '2006-02-14 21:34:33'),
(172, 'GROUCHO', 'WILLIAMS', '2006-02-14 21:34:33'),
(173, 'ALAN', 'DREYFUSS', '2006-02-14 21:34:33'),
(174, 'MICHAEL', 'BENING', '2006-02-14 21:34:33'),
(175, 'WILLIAM', 'HACKMAN', '2006-02-14 21:34:33'),
(176, 'JON', 'CHASE', '2006-02-14 21:34:33'),
(177, 'GENE', 'MCKELLEN', '2006-02-14 21:34:33'),
(178, 'LISA', 'MONROE', '2006-02-14 21:34:33'),
(179, 'ED', 'GUINESS', '2006-02-14 21:34:33'),
(180, 'JEFF', 'SILVERSTONE', '2006-02-14 21:34:33'),
(181, 'MATTHEW', 'CARREY', '2006-02-14 21:34:33'),
(182, 'DEBBIE', 'AKROYD', '2006-02-14 21:34:33'),
(183, 'RUSSELL', 'CLOSE', '2006-02-14 21:34:33'),
(184, 'HUMPHREY', 'GARLAND', '2006-02-14 21:34:33'),
(185, 'MICHAEL', 'BOLGER', '2006-02-14 21:34:33'),
(186, 'JULIA', 'ZELLWEGER', '2006-02-14 21:34:33'),
(187, 'RENEE', 'BALL', '2006-02-14 21:34:33'),
(188, 'ROCK', 'DUKAKIS', '2006-02-14 21:34:33'),
(189, 'CUBA', 'BIRCH', '2006-02-14 21:34:33'),
(190, 'AUDREY', 'BAILEY', '2006-02-14 21:34:33'),
(191, 'GREGORY', 'GOODING', '2006-02-14 21:34:33'),
(192, 'JOHN', 'SUVARI', '2006-02-14 21:34:33'),
(193, 'BURT', 'TEMPLE', '2006-02-14 21:34:33'),
(194, 'MERYL', 'ALLEN', '2006-02-14 21:34:33'),
(195, 'JAYNE', 'SILVERSTONE', '2006-02-14 21:34:33'),
(196, 'BELA', 'WALKEN', '2006-02-14 21:34:33'),
(197, 'REESE', 'WEST', '2006-02-14 21:34:33'),
(198, 'MARY', 'KEITEL', '2006-02-14 21:34:33'),
(199, 'JULIA', 'FAWCETT', '2006-02-14 21:34:33'),
(200, 'THORA', 'TEMPLE', '2006-02-14 21:34:33');

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `actor_info`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `actor_info` (
`actor_id` smallint(5) unsigned
,`first_name` varchar(45)
,`last_name` varchar(45)
,`film_info` text
);

-- --------------------------------------------------------

--
-- Struktur dari tabel `address`
--

CREATE TABLE `address` (
  `address_id` smallint(5) UNSIGNED NOT NULL,
  `address` varchar(50) NOT NULL,
  `address2` varchar(50) DEFAULT NULL,
  `district` varchar(20) NOT NULL,
  `city_id` smallint(5) UNSIGNED NOT NULL,
  `postal_code` varchar(10) DEFAULT NULL,
  `phone` varchar(20) NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Struktur dari tabel `category`
--

CREATE TABLE `category` (
  `category_id` tinyint(3) UNSIGNED NOT NULL,
  `name` varchar(25) NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

--
-- Dumping data untuk tabel `category`
--

INSERT INTO `category` (`category_id`, `name`, `last_update`) VALUES
(1, 'Action', '2006-02-14 21:46:27'),
(2, 'Animation', '2006-02-14 21:46:27'),
(3, 'Children', '2006-02-14 21:46:27'),
(4, 'Classics', '2006-02-14 21:46:27'),
(5, 'Comedy', '2006-02-14 21:46:27'),
(6, 'Documentary', '2006-02-14 21:46:27'),
(7, 'Drama', '2006-02-14 21:46:27'),
(8, 'Family', '2006-02-14 21:46:27'),
(9, 'Foreign', '2006-02-14 21:46:27'),
(10, 'Games', '2006-02-14 21:46:27'),
(11, 'Horror', '2006-02-14 21:46:27'),
(12, 'Music', '2006-02-14 21:46:27'),
(13, 'New', '2006-02-14 21:46:27'),
(14, 'Sci-Fi', '2006-02-14 21:46:27'),
(15, 'Sports', '2006-02-14 21:46:27'),
(16, 'Travel', '2006-02-14 21:46:27');

-- --------------------------------------------------------

--
-- Struktur dari tabel `city`
--

CREATE TABLE `city` (
  `city_id` smallint(5) UNSIGNED NOT NULL,
  `city` varchar(50) NOT NULL,
  `country_id` smallint(5) UNSIGNED NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

--
-- Dumping data untuk tabel `city`
--

INSERT INTO `city` (`city_id`, `city`, `country_id`, `last_update`) VALUES
(1, 'A Corua (La Corua)', 87, '2006-02-14 21:45:25'),
(2, 'Abha', 82, '2006-02-14 21:45:25'),
(3, 'Abu Dhabi', 101, '2006-02-14 21:45:25'),
(4, 'Acua', 60, '2006-02-14 21:45:25'),
(5, 'Adana', 97, '2006-02-14 21:45:25'),
(6, 'Addis Abeba', 31, '2006-02-14 21:45:25'),
(7, 'Aden', 107, '2006-02-14 21:45:25'),
(8, 'Adoni', 44, '2006-02-14 21:45:25'),
(9, 'Ahmadnagar', 44, '2006-02-14 21:45:25'),
(10, 'Akishima', 50, '2006-02-14 21:45:25'),
(11, 'Akron', 103, '2006-02-14 21:45:25'),
(12, 'al-Ayn', 101, '2006-02-14 21:45:25'),
(13, 'al-Hawiya', 82, '2006-02-14 21:45:25'),
(14, 'al-Manama', 11, '2006-02-14 21:45:25'),
(15, 'al-Qadarif', 89, '2006-02-14 21:45:25'),
(16, 'al-Qatif', 82, '2006-02-14 21:45:25'),
(17, 'Alessandria', 49, '2006-02-14 21:45:25'),
(18, 'Allappuzha (Alleppey)', 44, '2006-02-14 21:45:25'),
(19, 'Allende', 60, '2006-02-14 21:45:25'),
(20, 'Almirante Brown', 6, '2006-02-14 21:45:25'),
(21, 'Alvorada', 15, '2006-02-14 21:45:25'),
(22, 'Ambattur', 44, '2006-02-14 21:45:25'),
(23, 'Amersfoort', 67, '2006-02-14 21:45:25'),
(24, 'Amroha', 44, '2006-02-14 21:45:25'),
(25, 'Angra dos Reis', 15, '2006-02-14 21:45:25'),
(26, 'Anpolis', 15, '2006-02-14 21:45:25'),
(27, 'Antofagasta', 22, '2006-02-14 21:45:25'),
(28, 'Aparecida de Goinia', 15, '2006-02-14 21:45:25'),
(29, 'Apeldoorn', 67, '2006-02-14 21:45:25'),
(30, 'Araatuba', 15, '2006-02-14 21:45:25'),
(31, 'Arak', 46, '2006-02-14 21:45:25'),
(32, 'Arecibo', 77, '2006-02-14 21:45:25'),
(33, 'Arlington', 103, '2006-02-14 21:45:25'),
(34, 'Ashdod', 48, '2006-02-14 21:45:25'),
(35, 'Ashgabat', 98, '2006-02-14 21:45:25'),
(36, 'Ashqelon', 48, '2006-02-14 21:45:25'),
(37, 'Asuncin', 73, '2006-02-14 21:45:25'),
(38, 'Athenai', 39, '2006-02-14 21:45:25'),
(39, 'Atinsk', 80, '2006-02-14 21:45:25'),
(40, 'Atlixco', 60, '2006-02-14 21:45:25'),
(41, 'Augusta-Richmond County', 103, '2006-02-14 21:45:25'),
(42, 'Aurora', 103, '2006-02-14 21:45:25'),
(43, 'Avellaneda', 6, '2006-02-14 21:45:25'),
(44, 'Bag', 15, '2006-02-14 21:45:25'),
(45, 'Baha Blanca', 6, '2006-02-14 21:45:25'),
(46, 'Baicheng', 23, '2006-02-14 21:45:25'),
(47, 'Baiyin', 23, '2006-02-14 21:45:25'),
(48, 'Baku', 10, '2006-02-14 21:45:25'),
(49, 'Balaiha', 80, '2006-02-14 21:45:25'),
(50, 'Balikesir', 97, '2006-02-14 21:45:25'),
(51, 'Balurghat', 44, '2006-02-14 21:45:25'),
(52, 'Bamenda', 19, '2006-02-14 21:45:25'),
(53, 'Bandar Seri Begawan', 16, '2006-02-14 21:45:25'),
(54, 'Banjul', 37, '2006-02-14 21:45:25'),
(55, 'Barcelona', 104, '2006-02-14 21:45:25'),
(56, 'Basel', 91, '2006-02-14 21:45:25'),
(57, 'Bat Yam', 48, '2006-02-14 21:45:25'),
(58, 'Batman', 97, '2006-02-14 21:45:25'),
(59, 'Batna', 2, '2006-02-14 21:45:25'),
(60, 'Battambang', 18, '2006-02-14 21:45:25'),
(61, 'Baybay', 75, '2006-02-14 21:45:25'),
(62, 'Bayugan', 75, '2006-02-14 21:45:25'),
(63, 'Bchar', 2, '2006-02-14 21:45:25'),
(64, 'Beira', 63, '2006-02-14 21:45:25'),
(65, 'Bellevue', 103, '2006-02-14 21:45:25'),
(66, 'Belm', 15, '2006-02-14 21:45:25'),
(67, 'Benguela', 4, '2006-02-14 21:45:25'),
(68, 'Beni-Mellal', 62, '2006-02-14 21:45:25'),
(69, 'Benin City', 69, '2006-02-14 21:45:25'),
(70, 'Bergamo', 49, '2006-02-14 21:45:25'),
(71, 'Berhampore (Baharampur)', 44, '2006-02-14 21:45:25'),
(72, 'Bern', 91, '2006-02-14 21:45:25'),
(73, 'Bhavnagar', 44, '2006-02-14 21:45:25'),
(74, 'Bhilwara', 44, '2006-02-14 21:45:25'),
(75, 'Bhimavaram', 44, '2006-02-14 21:45:25'),
(76, 'Bhopal', 44, '2006-02-14 21:45:25'),
(77, 'Bhusawal', 44, '2006-02-14 21:45:25'),
(78, 'Bijapur', 44, '2006-02-14 21:45:25'),
(79, 'Bilbays', 29, '2006-02-14 21:45:25'),
(80, 'Binzhou', 23, '2006-02-14 21:45:25'),
(81, 'Birgunj', 66, '2006-02-14 21:45:25'),
(82, 'Bislig', 75, '2006-02-14 21:45:25'),
(83, 'Blumenau', 15, '2006-02-14 21:45:25'),
(84, 'Boa Vista', 15, '2006-02-14 21:45:25'),
(85, 'Boksburg', 85, '2006-02-14 21:45:25'),
(86, 'Botosani', 78, '2006-02-14 21:45:25'),
(87, 'Botshabelo', 85, '2006-02-14 21:45:25'),
(88, 'Bradford', 102, '2006-02-14 21:45:25'),
(89, 'Braslia', 15, '2006-02-14 21:45:25'),
(90, 'Bratislava', 84, '2006-02-14 21:45:25'),
(91, 'Brescia', 49, '2006-02-14 21:45:25'),
(92, 'Brest', 34, '2006-02-14 21:45:25'),
(93, 'Brindisi', 49, '2006-02-14 21:45:25'),
(94, 'Brockton', 103, '2006-02-14 21:45:25'),
(95, 'Bucuresti', 78, '2006-02-14 21:45:25'),
(96, 'Buenaventura', 24, '2006-02-14 21:45:25'),
(97, 'Bydgoszcz', 76, '2006-02-14 21:45:25'),
(98, 'Cabuyao', 75, '2006-02-14 21:45:25'),
(99, 'Callao', 74, '2006-02-14 21:45:25'),
(100, 'Cam Ranh', 105, '2006-02-14 21:45:25'),
(101, 'Cape Coral', 103, '2006-02-14 21:45:25'),
(102, 'Caracas', 104, '2006-02-14 21:45:25'),
(103, 'Carmen', 60, '2006-02-14 21:45:25'),
(104, 'Cavite', 75, '2006-02-14 21:45:25'),
(105, 'Cayenne', 35, '2006-02-14 21:45:25'),
(106, 'Celaya', 60, '2006-02-14 21:45:25'),
(107, 'Chandrapur', 44, '2006-02-14 21:45:25'),
(108, 'Changhwa', 92, '2006-02-14 21:45:25'),
(109, 'Changzhou', 23, '2006-02-14 21:45:25'),
(110, 'Chapra', 44, '2006-02-14 21:45:25'),
(111, 'Charlotte Amalie', 106, '2006-02-14 21:45:25'),
(112, 'Chatsworth', 85, '2006-02-14 21:45:25'),
(113, 'Cheju', 86, '2006-02-14 21:45:25'),
(114, 'Chiayi', 92, '2006-02-14 21:45:25'),
(115, 'Chisinau', 61, '2006-02-14 21:45:25'),
(116, 'Chungho', 92, '2006-02-14 21:45:25'),
(117, 'Cianjur', 45, '2006-02-14 21:45:25'),
(118, 'Ciomas', 45, '2006-02-14 21:45:25'),
(119, 'Ciparay', 45, '2006-02-14 21:45:25'),
(120, 'Citrus Heights', 103, '2006-02-14 21:45:25'),
(121, 'Citt del Vaticano', 41, '2006-02-14 21:45:25'),
(122, 'Ciudad del Este', 73, '2006-02-14 21:45:25'),
(123, 'Clarksville', 103, '2006-02-14 21:45:25'),
(124, 'Coacalco de Berriozbal', 60, '2006-02-14 21:45:25'),
(125, 'Coatzacoalcos', 60, '2006-02-14 21:45:25'),
(126, 'Compton', 103, '2006-02-14 21:45:25'),
(127, 'Coquimbo', 22, '2006-02-14 21:45:25'),
(128, 'Crdoba', 6, '2006-02-14 21:45:25'),
(129, 'Cuauhtmoc', 60, '2006-02-14 21:45:25'),
(130, 'Cuautla', 60, '2006-02-14 21:45:25'),
(131, 'Cuernavaca', 60, '2006-02-14 21:45:25'),
(132, 'Cuman', 104, '2006-02-14 21:45:25'),
(133, 'Czestochowa', 76, '2006-02-14 21:45:25'),
(134, 'Dadu', 72, '2006-02-14 21:45:25'),
(135, 'Dallas', 103, '2006-02-14 21:45:25'),
(136, 'Datong', 23, '2006-02-14 21:45:25'),
(137, 'Daugavpils', 54, '2006-02-14 21:45:25'),
(138, 'Davao', 75, '2006-02-14 21:45:25'),
(139, 'Daxian', 23, '2006-02-14 21:45:25'),
(140, 'Dayton', 103, '2006-02-14 21:45:25'),
(141, 'Deba Habe', 69, '2006-02-14 21:45:25'),
(142, 'Denizli', 97, '2006-02-14 21:45:25'),
(143, 'Dhaka', 12, '2006-02-14 21:45:25'),
(144, 'Dhule (Dhulia)', 44, '2006-02-14 21:45:25'),
(145, 'Dongying', 23, '2006-02-14 21:45:25'),
(146, 'Donostia-San Sebastin', 87, '2006-02-14 21:45:25'),
(147, 'Dos Quebradas', 24, '2006-02-14 21:45:25'),
(148, 'Duisburg', 38, '2006-02-14 21:45:25'),
(149, 'Dundee', 102, '2006-02-14 21:45:25'),
(150, 'Dzerzinsk', 80, '2006-02-14 21:45:25'),
(151, 'Ede', 67, '2006-02-14 21:45:25'),
(152, 'Effon-Alaiye', 69, '2006-02-14 21:45:25'),
(153, 'El Alto', 14, '2006-02-14 21:45:25'),
(154, 'El Fuerte', 60, '2006-02-14 21:45:25'),
(155, 'El Monte', 103, '2006-02-14 21:45:25'),
(156, 'Elista', 80, '2006-02-14 21:45:25'),
(157, 'Emeishan', 23, '2006-02-14 21:45:25'),
(158, 'Emmen', 67, '2006-02-14 21:45:25'),
(159, 'Enshi', 23, '2006-02-14 21:45:25'),
(160, 'Erlangen', 38, '2006-02-14 21:45:25'),
(161, 'Escobar', 6, '2006-02-14 21:45:25'),
(162, 'Esfahan', 46, '2006-02-14 21:45:25'),
(163, 'Eskisehir', 97, '2006-02-14 21:45:25'),
(164, 'Etawah', 44, '2006-02-14 21:45:25'),
(165, 'Ezeiza', 6, '2006-02-14 21:45:25'),
(166, 'Ezhou', 23, '2006-02-14 21:45:25'),
(167, 'Faaa', 36, '2006-02-14 21:45:25'),
(168, 'Fengshan', 92, '2006-02-14 21:45:25'),
(169, 'Firozabad', 44, '2006-02-14 21:45:25'),
(170, 'Florencia', 24, '2006-02-14 21:45:25'),
(171, 'Fontana', 103, '2006-02-14 21:45:25'),
(172, 'Fukuyama', 50, '2006-02-14 21:45:25'),
(173, 'Funafuti', 99, '2006-02-14 21:45:25'),
(174, 'Fuyu', 23, '2006-02-14 21:45:25'),
(175, 'Fuzhou', 23, '2006-02-14 21:45:25'),
(176, 'Gandhinagar', 44, '2006-02-14 21:45:25'),
(177, 'Garden Grove', 103, '2006-02-14 21:45:25'),
(178, 'Garland', 103, '2006-02-14 21:45:25'),
(179, 'Gatineau', 20, '2006-02-14 21:45:25'),
(180, 'Gaziantep', 97, '2006-02-14 21:45:25'),
(181, 'Gijn', 87, '2006-02-14 21:45:25'),
(182, 'Gingoog', 75, '2006-02-14 21:45:25'),
(183, 'Goinia', 15, '2006-02-14 21:45:25'),
(184, 'Gorontalo', 45, '2006-02-14 21:45:25'),
(185, 'Grand Prairie', 103, '2006-02-14 21:45:25'),
(186, 'Graz', 9, '2006-02-14 21:45:25'),
(187, 'Greensboro', 103, '2006-02-14 21:45:25'),
(188, 'Guadalajara', 60, '2006-02-14 21:45:25'),
(189, 'Guaruj', 15, '2006-02-14 21:45:25'),
(190, 'guas Lindas de Gois', 15, '2006-02-14 21:45:25'),
(191, 'Gulbarga', 44, '2006-02-14 21:45:25'),
(192, 'Hagonoy', 75, '2006-02-14 21:45:25'),
(193, 'Haining', 23, '2006-02-14 21:45:25'),
(194, 'Haiphong', 105, '2006-02-14 21:45:25'),
(195, 'Haldia', 44, '2006-02-14 21:45:25'),
(196, 'Halifax', 20, '2006-02-14 21:45:25'),
(197, 'Halisahar', 44, '2006-02-14 21:45:25'),
(198, 'Halle/Saale', 38, '2006-02-14 21:45:25'),
(199, 'Hami', 23, '2006-02-14 21:45:25'),
(200, 'Hamilton', 68, '2006-02-14 21:45:25'),
(201, 'Hanoi', 105, '2006-02-14 21:45:25'),
(202, 'Hidalgo', 60, '2006-02-14 21:45:25'),
(203, 'Higashiosaka', 50, '2006-02-14 21:45:25'),
(204, 'Hino', 50, '2006-02-14 21:45:25'),
(205, 'Hiroshima', 50, '2006-02-14 21:45:25'),
(206, 'Hodeida', 107, '2006-02-14 21:45:25'),
(207, 'Hohhot', 23, '2006-02-14 21:45:25'),
(208, 'Hoshiarpur', 44, '2006-02-14 21:45:25'),
(209, 'Hsichuh', 92, '2006-02-14 21:45:25'),
(210, 'Huaian', 23, '2006-02-14 21:45:25'),
(211, 'Hubli-Dharwad', 44, '2006-02-14 21:45:25'),
(212, 'Huejutla de Reyes', 60, '2006-02-14 21:45:25'),
(213, 'Huixquilucan', 60, '2006-02-14 21:45:25'),
(214, 'Hunuco', 74, '2006-02-14 21:45:25'),
(215, 'Ibirit', 15, '2006-02-14 21:45:25'),
(216, 'Idfu', 29, '2006-02-14 21:45:25'),
(217, 'Ife', 69, '2006-02-14 21:45:25'),
(218, 'Ikerre', 69, '2006-02-14 21:45:25'),
(219, 'Iligan', 75, '2006-02-14 21:45:25'),
(220, 'Ilorin', 69, '2006-02-14 21:45:25'),
(221, 'Imus', 75, '2006-02-14 21:45:25'),
(222, 'Inegl', 97, '2006-02-14 21:45:25'),
(223, 'Ipoh', 59, '2006-02-14 21:45:25'),
(224, 'Isesaki', 50, '2006-02-14 21:45:25'),
(225, 'Ivanovo', 80, '2006-02-14 21:45:25'),
(226, 'Iwaki', 50, '2006-02-14 21:45:25'),
(227, 'Iwakuni', 50, '2006-02-14 21:45:25'),
(228, 'Iwatsuki', 50, '2006-02-14 21:45:25'),
(229, 'Izumisano', 50, '2006-02-14 21:45:25'),
(230, 'Jaffna', 88, '2006-02-14 21:45:25'),
(231, 'Jaipur', 44, '2006-02-14 21:45:25'),
(232, 'Jakarta', 45, '2006-02-14 21:45:25'),
(233, 'Jalib al-Shuyukh', 53, '2006-02-14 21:45:25'),
(234, 'Jamalpur', 12, '2006-02-14 21:45:25'),
(235, 'Jaroslavl', 80, '2006-02-14 21:45:25'),
(236, 'Jastrzebie-Zdrj', 76, '2006-02-14 21:45:25'),
(237, 'Jedda', 82, '2006-02-14 21:45:25'),
(238, 'Jelets', 80, '2006-02-14 21:45:25'),
(239, 'Jhansi', 44, '2006-02-14 21:45:25'),
(240, 'Jinchang', 23, '2006-02-14 21:45:25'),
(241, 'Jining', 23, '2006-02-14 21:45:25'),
(242, 'Jinzhou', 23, '2006-02-14 21:45:25'),
(243, 'Jodhpur', 44, '2006-02-14 21:45:25'),
(244, 'Johannesburg', 85, '2006-02-14 21:45:25'),
(245, 'Joliet', 103, '2006-02-14 21:45:25'),
(246, 'Jos Azueta', 60, '2006-02-14 21:45:25'),
(247, 'Juazeiro do Norte', 15, '2006-02-14 21:45:25'),
(248, 'Juiz de Fora', 15, '2006-02-14 21:45:25'),
(249, 'Junan', 23, '2006-02-14 21:45:25'),
(250, 'Jurez', 60, '2006-02-14 21:45:25'),
(251, 'Kabul', 1, '2006-02-14 21:45:25'),
(252, 'Kaduna', 69, '2006-02-14 21:45:25'),
(253, 'Kakamigahara', 50, '2006-02-14 21:45:25'),
(254, 'Kaliningrad', 80, '2006-02-14 21:45:25'),
(255, 'Kalisz', 76, '2006-02-14 21:45:25'),
(256, 'Kamakura', 50, '2006-02-14 21:45:25'),
(257, 'Kamarhati', 44, '2006-02-14 21:45:25'),
(258, 'Kamjanets-Podilskyi', 100, '2006-02-14 21:45:25'),
(259, 'Kamyin', 80, '2006-02-14 21:45:25'),
(260, 'Kanazawa', 50, '2006-02-14 21:45:25'),
(261, 'Kanchrapara', 44, '2006-02-14 21:45:25'),
(262, 'Kansas City', 103, '2006-02-14 21:45:25'),
(263, 'Karnal', 44, '2006-02-14 21:45:25'),
(264, 'Katihar', 44, '2006-02-14 21:45:25'),
(265, 'Kermanshah', 46, '2006-02-14 21:45:25'),
(266, 'Kilis', 97, '2006-02-14 21:45:25'),
(267, 'Kimberley', 85, '2006-02-14 21:45:25'),
(268, 'Kimchon', 86, '2006-02-14 21:45:25'),
(269, 'Kingstown', 81, '2006-02-14 21:45:25'),
(270, 'Kirovo-Tepetsk', 80, '2006-02-14 21:45:25'),
(271, 'Kisumu', 52, '2006-02-14 21:45:25'),
(272, 'Kitwe', 109, '2006-02-14 21:45:25'),
(273, 'Klerksdorp', 85, '2006-02-14 21:45:25'),
(274, 'Kolpino', 80, '2006-02-14 21:45:25'),
(275, 'Konotop', 100, '2006-02-14 21:45:25'),
(276, 'Koriyama', 50, '2006-02-14 21:45:25'),
(277, 'Korla', 23, '2006-02-14 21:45:25'),
(278, 'Korolev', 80, '2006-02-14 21:45:25'),
(279, 'Kowloon and New Kowloon', 42, '2006-02-14 21:45:25'),
(280, 'Kragujevac', 108, '2006-02-14 21:45:25'),
(281, 'Ktahya', 97, '2006-02-14 21:45:25'),
(282, 'Kuching', 59, '2006-02-14 21:45:25'),
(283, 'Kumbakonam', 44, '2006-02-14 21:45:25'),
(284, 'Kurashiki', 50, '2006-02-14 21:45:25'),
(285, 'Kurgan', 80, '2006-02-14 21:45:25'),
(286, 'Kursk', 80, '2006-02-14 21:45:25'),
(287, 'Kuwana', 50, '2006-02-14 21:45:25'),
(288, 'La Paz', 60, '2006-02-14 21:45:25'),
(289, 'La Plata', 6, '2006-02-14 21:45:25'),
(290, 'La Romana', 27, '2006-02-14 21:45:25'),
(291, 'Laiwu', 23, '2006-02-14 21:45:25'),
(292, 'Lancaster', 103, '2006-02-14 21:45:25'),
(293, 'Laohekou', 23, '2006-02-14 21:45:25'),
(294, 'Lapu-Lapu', 75, '2006-02-14 21:45:25'),
(295, 'Laredo', 103, '2006-02-14 21:45:25'),
(296, 'Lausanne', 91, '2006-02-14 21:45:25'),
(297, 'Le Mans', 34, '2006-02-14 21:45:25'),
(298, 'Lengshuijiang', 23, '2006-02-14 21:45:25'),
(299, 'Leshan', 23, '2006-02-14 21:45:25'),
(300, 'Lethbridge', 20, '2006-02-14 21:45:25'),
(301, 'Lhokseumawe', 45, '2006-02-14 21:45:25'),
(302, 'Liaocheng', 23, '2006-02-14 21:45:25'),
(303, 'Liepaja', 54, '2006-02-14 21:45:25'),
(304, 'Lilongwe', 58, '2006-02-14 21:45:25'),
(305, 'Lima', 74, '2006-02-14 21:45:25'),
(306, 'Lincoln', 103, '2006-02-14 21:45:25'),
(307, 'Linz', 9, '2006-02-14 21:45:25'),
(308, 'Lipetsk', 80, '2006-02-14 21:45:25'),
(309, 'Livorno', 49, '2006-02-14 21:45:25'),
(310, 'Ljubertsy', 80, '2006-02-14 21:45:25'),
(311, 'Loja', 28, '2006-02-14 21:45:25'),
(312, 'London', 102, '2006-02-14 21:45:25'),
(313, 'London', 20, '2006-02-14 21:45:25'),
(314, 'Lublin', 76, '2006-02-14 21:45:25'),
(315, 'Lubumbashi', 25, '2006-02-14 21:45:25'),
(316, 'Lungtan', 92, '2006-02-14 21:45:25'),
(317, 'Luzinia', 15, '2006-02-14 21:45:25'),
(318, 'Madiun', 45, '2006-02-14 21:45:25'),
(319, 'Mahajanga', 57, '2006-02-14 21:45:25'),
(320, 'Maikop', 80, '2006-02-14 21:45:25'),
(321, 'Malm', 90, '2006-02-14 21:45:25'),
(322, 'Manchester', 103, '2006-02-14 21:45:25'),
(323, 'Mandaluyong', 75, '2006-02-14 21:45:25'),
(324, 'Mandi Bahauddin', 72, '2006-02-14 21:45:25'),
(325, 'Mannheim', 38, '2006-02-14 21:45:25'),
(326, 'Maracabo', 104, '2006-02-14 21:45:25'),
(327, 'Mardan', 72, '2006-02-14 21:45:25'),
(328, 'Maring', 15, '2006-02-14 21:45:25'),
(329, 'Masqat', 71, '2006-02-14 21:45:25'),
(330, 'Matamoros', 60, '2006-02-14 21:45:25'),
(331, 'Matsue', 50, '2006-02-14 21:45:25'),
(332, 'Meixian', 23, '2006-02-14 21:45:25'),
(333, 'Memphis', 103, '2006-02-14 21:45:25'),
(334, 'Merlo', 6, '2006-02-14 21:45:25'),
(335, 'Mexicali', 60, '2006-02-14 21:45:25'),
(336, 'Miraj', 44, '2006-02-14 21:45:25'),
(337, 'Mit Ghamr', 29, '2006-02-14 21:45:25'),
(338, 'Miyakonojo', 50, '2006-02-14 21:45:25'),
(339, 'Mogiljov', 13, '2006-02-14 21:45:25'),
(340, 'Molodetno', 13, '2006-02-14 21:45:25'),
(341, 'Monclova', 60, '2006-02-14 21:45:25'),
(342, 'Monywa', 64, '2006-02-14 21:45:25'),
(343, 'Moscow', 80, '2006-02-14 21:45:25'),
(344, 'Mosul', 47, '2006-02-14 21:45:25'),
(345, 'Mukateve', 100, '2006-02-14 21:45:25'),
(346, 'Munger (Monghyr)', 44, '2006-02-14 21:45:25'),
(347, 'Mwanza', 93, '2006-02-14 21:45:25'),
(348, 'Mwene-Ditu', 25, '2006-02-14 21:45:25'),
(349, 'Myingyan', 64, '2006-02-14 21:45:25'),
(350, 'Mysore', 44, '2006-02-14 21:45:25'),
(351, 'Naala-Porto', 63, '2006-02-14 21:45:25'),
(352, 'Nabereznyje Telny', 80, '2006-02-14 21:45:25'),
(353, 'Nador', 62, '2006-02-14 21:45:25'),
(354, 'Nagaon', 44, '2006-02-14 21:45:25'),
(355, 'Nagareyama', 50, '2006-02-14 21:45:25'),
(356, 'Najafabad', 46, '2006-02-14 21:45:25'),
(357, 'Naju', 86, '2006-02-14 21:45:25'),
(358, 'Nakhon Sawan', 94, '2006-02-14 21:45:25'),
(359, 'Nam Dinh', 105, '2006-02-14 21:45:25'),
(360, 'Namibe', 4, '2006-02-14 21:45:25'),
(361, 'Nantou', 92, '2006-02-14 21:45:25'),
(362, 'Nanyang', 23, '2006-02-14 21:45:25'),
(363, 'NDjamna', 21, '2006-02-14 21:45:25'),
(364, 'Newcastle', 85, '2006-02-14 21:45:25'),
(365, 'Nezahualcyotl', 60, '2006-02-14 21:45:25'),
(366, 'Nha Trang', 105, '2006-02-14 21:45:25'),
(367, 'Niznekamsk', 80, '2006-02-14 21:45:25'),
(368, 'Novi Sad', 108, '2006-02-14 21:45:25'),
(369, 'Novoterkassk', 80, '2006-02-14 21:45:25'),
(370, 'Nukualofa', 95, '2006-02-14 21:45:25'),
(371, 'Nuuk', 40, '2006-02-14 21:45:25'),
(372, 'Nyeri', 52, '2006-02-14 21:45:25'),
(373, 'Ocumare del Tuy', 104, '2006-02-14 21:45:25'),
(374, 'Ogbomosho', 69, '2006-02-14 21:45:25'),
(375, 'Okara', 72, '2006-02-14 21:45:25'),
(376, 'Okayama', 50, '2006-02-14 21:45:25'),
(377, 'Okinawa', 50, '2006-02-14 21:45:25'),
(378, 'Olomouc', 26, '2006-02-14 21:45:25'),
(379, 'Omdurman', 89, '2006-02-14 21:45:25'),
(380, 'Omiya', 50, '2006-02-14 21:45:25'),
(381, 'Ondo', 69, '2006-02-14 21:45:25'),
(382, 'Onomichi', 50, '2006-02-14 21:45:25'),
(383, 'Oshawa', 20, '2006-02-14 21:45:25'),
(384, 'Osmaniye', 97, '2006-02-14 21:45:25'),
(385, 'ostka', 100, '2006-02-14 21:45:25'),
(386, 'Otsu', 50, '2006-02-14 21:45:25'),
(387, 'Oulu', 33, '2006-02-14 21:45:25'),
(388, 'Ourense (Orense)', 87, '2006-02-14 21:45:25'),
(389, 'Owo', 69, '2006-02-14 21:45:25'),
(390, 'Oyo', 69, '2006-02-14 21:45:25'),
(391, 'Ozamis', 75, '2006-02-14 21:45:25'),
(392, 'Paarl', 85, '2006-02-14 21:45:25'),
(393, 'Pachuca de Soto', 60, '2006-02-14 21:45:25'),
(394, 'Pak Kret', 94, '2006-02-14 21:45:25'),
(395, 'Palghat (Palakkad)', 44, '2006-02-14 21:45:25'),
(396, 'Pangkal Pinang', 45, '2006-02-14 21:45:25'),
(397, 'Papeete', 36, '2006-02-14 21:45:25'),
(398, 'Parbhani', 44, '2006-02-14 21:45:25'),
(399, 'Pathankot', 44, '2006-02-14 21:45:25'),
(400, 'Patiala', 44, '2006-02-14 21:45:25'),
(401, 'Patras', 39, '2006-02-14 21:45:25'),
(402, 'Pavlodar', 51, '2006-02-14 21:45:25'),
(403, 'Pemalang', 45, '2006-02-14 21:45:25'),
(404, 'Peoria', 103, '2006-02-14 21:45:25'),
(405, 'Pereira', 24, '2006-02-14 21:45:25'),
(406, 'Phnom Penh', 18, '2006-02-14 21:45:25'),
(407, 'Pingxiang', 23, '2006-02-14 21:45:25'),
(408, 'Pjatigorsk', 80, '2006-02-14 21:45:25'),
(409, 'Plock', 76, '2006-02-14 21:45:25'),
(410, 'Po', 15, '2006-02-14 21:45:25'),
(411, 'Ponce', 77, '2006-02-14 21:45:25'),
(412, 'Pontianak', 45, '2006-02-14 21:45:25'),
(413, 'Poos de Caldas', 15, '2006-02-14 21:45:25'),
(414, 'Portoviejo', 28, '2006-02-14 21:45:25'),
(415, 'Probolinggo', 45, '2006-02-14 21:45:25'),
(416, 'Pudukkottai', 44, '2006-02-14 21:45:25'),
(417, 'Pune', 44, '2006-02-14 21:45:25'),
(418, 'Purnea (Purnia)', 44, '2006-02-14 21:45:25'),
(419, 'Purwakarta', 45, '2006-02-14 21:45:25'),
(420, 'Pyongyang', 70, '2006-02-14 21:45:25'),
(421, 'Qalyub', 29, '2006-02-14 21:45:25'),
(422, 'Qinhuangdao', 23, '2006-02-14 21:45:25'),
(423, 'Qomsheh', 46, '2006-02-14 21:45:25'),
(424, 'Quilmes', 6, '2006-02-14 21:45:25'),
(425, 'Rae Bareli', 44, '2006-02-14 21:45:25'),
(426, 'Rajkot', 44, '2006-02-14 21:45:25'),
(427, 'Rampur', 44, '2006-02-14 21:45:25'),
(428, 'Rancagua', 22, '2006-02-14 21:45:25'),
(429, 'Ranchi', 44, '2006-02-14 21:45:25'),
(430, 'Richmond Hill', 20, '2006-02-14 21:45:25'),
(431, 'Rio Claro', 15, '2006-02-14 21:45:25'),
(432, 'Rizhao', 23, '2006-02-14 21:45:25'),
(433, 'Roanoke', 103, '2006-02-14 21:45:25'),
(434, 'Robamba', 28, '2006-02-14 21:45:25'),
(435, 'Rockford', 103, '2006-02-14 21:45:25'),
(436, 'Ruse', 17, '2006-02-14 21:45:25'),
(437, 'Rustenburg', 85, '2006-02-14 21:45:25'),
(438, 's-Hertogenbosch', 67, '2006-02-14 21:45:25'),
(439, 'Saarbrcken', 38, '2006-02-14 21:45:25'),
(440, 'Sagamihara', 50, '2006-02-14 21:45:25'),
(441, 'Saint Louis', 103, '2006-02-14 21:45:25'),
(442, 'Saint-Denis', 79, '2006-02-14 21:45:25'),
(443, 'Sal', 62, '2006-02-14 21:45:25'),
(444, 'Salala', 71, '2006-02-14 21:45:25'),
(445, 'Salamanca', 60, '2006-02-14 21:45:25'),
(446, 'Salinas', 103, '2006-02-14 21:45:25'),
(447, 'Salzburg', 9, '2006-02-14 21:45:25'),
(448, 'Sambhal', 44, '2006-02-14 21:45:25'),
(449, 'San Bernardino', 103, '2006-02-14 21:45:25'),
(450, 'San Felipe de Puerto Plata', 27, '2006-02-14 21:45:25'),
(451, 'San Felipe del Progreso', 60, '2006-02-14 21:45:25'),
(452, 'San Juan Bautista Tuxtepec', 60, '2006-02-14 21:45:25'),
(453, 'San Lorenzo', 73, '2006-02-14 21:45:25'),
(454, 'San Miguel de Tucumn', 6, '2006-02-14 21:45:25'),
(455, 'Sanaa', 107, '2006-02-14 21:45:25'),
(456, 'Santa Brbara dOeste', 15, '2006-02-14 21:45:25'),
(457, 'Santa F', 6, '2006-02-14 21:45:25'),
(458, 'Santa Rosa', 75, '2006-02-14 21:45:25'),
(459, 'Santiago de Compostela', 87, '2006-02-14 21:45:25'),
(460, 'Santiago de los Caballeros', 27, '2006-02-14 21:45:25'),
(461, 'Santo Andr', 15, '2006-02-14 21:45:25'),
(462, 'Sanya', 23, '2006-02-14 21:45:25'),
(463, 'Sasebo', 50, '2006-02-14 21:45:25'),
(464, 'Satna', 44, '2006-02-14 21:45:25'),
(465, 'Sawhaj', 29, '2006-02-14 21:45:25'),
(466, 'Serpuhov', 80, '2006-02-14 21:45:25'),
(467, 'Shahr-e Kord', 46, '2006-02-14 21:45:25'),
(468, 'Shanwei', 23, '2006-02-14 21:45:25'),
(469, 'Shaoguan', 23, '2006-02-14 21:45:25'),
(470, 'Sharja', 101, '2006-02-14 21:45:25'),
(471, 'Shenzhen', 23, '2006-02-14 21:45:25'),
(472, 'Shikarpur', 72, '2006-02-14 21:45:25'),
(473, 'Shimoga', 44, '2006-02-14 21:45:25'),
(474, 'Shimonoseki', 50, '2006-02-14 21:45:25'),
(475, 'Shivapuri', 44, '2006-02-14 21:45:25'),
(476, 'Shubra al-Khayma', 29, '2006-02-14 21:45:25'),
(477, 'Siegen', 38, '2006-02-14 21:45:25'),
(478, 'Siliguri (Shiliguri)', 44, '2006-02-14 21:45:25'),
(479, 'Simferopol', 100, '2006-02-14 21:45:25'),
(480, 'Sincelejo', 24, '2006-02-14 21:45:25'),
(481, 'Sirjan', 46, '2006-02-14 21:45:25'),
(482, 'Sivas', 97, '2006-02-14 21:45:25'),
(483, 'Skikda', 2, '2006-02-14 21:45:25'),
(484, 'Smolensk', 80, '2006-02-14 21:45:25'),
(485, 'So Bernardo do Campo', 15, '2006-02-14 21:45:25'),
(486, 'So Leopoldo', 15, '2006-02-14 21:45:25'),
(487, 'Sogamoso', 24, '2006-02-14 21:45:25'),
(488, 'Sokoto', 69, '2006-02-14 21:45:25'),
(489, 'Songkhla', 94, '2006-02-14 21:45:25'),
(490, 'Sorocaba', 15, '2006-02-14 21:45:25'),
(491, 'Soshanguve', 85, '2006-02-14 21:45:25'),
(492, 'Sousse', 96, '2006-02-14 21:45:25'),
(493, 'South Hill', 5, '2006-02-14 21:45:25'),
(494, 'Southampton', 102, '2006-02-14 21:45:25'),
(495, 'Southend-on-Sea', 102, '2006-02-14 21:45:25'),
(496, 'Southport', 102, '2006-02-14 21:45:25'),
(497, 'Springs', 85, '2006-02-14 21:45:25'),
(498, 'Stara Zagora', 17, '2006-02-14 21:45:25'),
(499, 'Sterling Heights', 103, '2006-02-14 21:45:25'),
(500, 'Stockport', 102, '2006-02-14 21:45:25'),
(501, 'Sucre', 14, '2006-02-14 21:45:25'),
(502, 'Suihua', 23, '2006-02-14 21:45:25'),
(503, 'Sullana', 74, '2006-02-14 21:45:25'),
(504, 'Sultanbeyli', 97, '2006-02-14 21:45:25'),
(505, 'Sumqayit', 10, '2006-02-14 21:45:25'),
(506, 'Sumy', 100, '2006-02-14 21:45:25'),
(507, 'Sungai Petani', 59, '2006-02-14 21:45:25'),
(508, 'Sunnyvale', 103, '2006-02-14 21:45:25'),
(509, 'Surakarta', 45, '2006-02-14 21:45:25'),
(510, 'Syktyvkar', 80, '2006-02-14 21:45:25'),
(511, 'Syrakusa', 49, '2006-02-14 21:45:25'),
(512, 'Szkesfehrvr', 43, '2006-02-14 21:45:25'),
(513, 'Tabora', 93, '2006-02-14 21:45:25'),
(514, 'Tabriz', 46, '2006-02-14 21:45:25'),
(515, 'Tabuk', 82, '2006-02-14 21:45:25'),
(516, 'Tafuna', 3, '2006-02-14 21:45:25'),
(517, 'Taguig', 75, '2006-02-14 21:45:25'),
(518, 'Taizz', 107, '2006-02-14 21:45:25'),
(519, 'Talavera', 75, '2006-02-14 21:45:25'),
(520, 'Tallahassee', 103, '2006-02-14 21:45:25'),
(521, 'Tama', 50, '2006-02-14 21:45:25'),
(522, 'Tambaram', 44, '2006-02-14 21:45:25'),
(523, 'Tanauan', 75, '2006-02-14 21:45:25'),
(524, 'Tandil', 6, '2006-02-14 21:45:25'),
(525, 'Tangail', 12, '2006-02-14 21:45:25'),
(526, 'Tanshui', 92, '2006-02-14 21:45:25'),
(527, 'Tanza', 75, '2006-02-14 21:45:25'),
(528, 'Tarlac', 75, '2006-02-14 21:45:25'),
(529, 'Tarsus', 97, '2006-02-14 21:45:25'),
(530, 'Tartu', 30, '2006-02-14 21:45:25'),
(531, 'Teboksary', 80, '2006-02-14 21:45:25'),
(532, 'Tegal', 45, '2006-02-14 21:45:25'),
(533, 'Tel Aviv-Jaffa', 48, '2006-02-14 21:45:25'),
(534, 'Tete', 63, '2006-02-14 21:45:25'),
(535, 'Tianjin', 23, '2006-02-14 21:45:25'),
(536, 'Tiefa', 23, '2006-02-14 21:45:25'),
(537, 'Tieli', 23, '2006-02-14 21:45:25'),
(538, 'Tokat', 97, '2006-02-14 21:45:25'),
(539, 'Tonghae', 86, '2006-02-14 21:45:25'),
(540, 'Tongliao', 23, '2006-02-14 21:45:25'),
(541, 'Torren', 60, '2006-02-14 21:45:25'),
(542, 'Touliu', 92, '2006-02-14 21:45:25'),
(543, 'Toulon', 34, '2006-02-14 21:45:25'),
(544, 'Toulouse', 34, '2006-02-14 21:45:25'),
(545, 'Trshavn', 32, '2006-02-14 21:45:25'),
(546, 'Tsaotun', 92, '2006-02-14 21:45:25'),
(547, 'Tsuyama', 50, '2006-02-14 21:45:25'),
(548, 'Tuguegarao', 75, '2006-02-14 21:45:25'),
(549, 'Tychy', 76, '2006-02-14 21:45:25'),
(550, 'Udaipur', 44, '2006-02-14 21:45:25'),
(551, 'Udine', 49, '2006-02-14 21:45:25'),
(552, 'Ueda', 50, '2006-02-14 21:45:25'),
(553, 'Uijongbu', 86, '2006-02-14 21:45:25'),
(554, 'Uluberia', 44, '2006-02-14 21:45:25'),
(555, 'Urawa', 50, '2006-02-14 21:45:25'),
(556, 'Uruapan', 60, '2006-02-14 21:45:25'),
(557, 'Usak', 97, '2006-02-14 21:45:25'),
(558, 'Usolje-Sibirskoje', 80, '2006-02-14 21:45:25'),
(559, 'Uttarpara-Kotrung', 44, '2006-02-14 21:45:25'),
(560, 'Vaduz', 55, '2006-02-14 21:45:25'),
(561, 'Valencia', 104, '2006-02-14 21:45:25'),
(562, 'Valle de la Pascua', 104, '2006-02-14 21:45:25'),
(563, 'Valle de Santiago', 60, '2006-02-14 21:45:25'),
(564, 'Valparai', 44, '2006-02-14 21:45:25'),
(565, 'Vancouver', 20, '2006-02-14 21:45:25'),
(566, 'Varanasi (Benares)', 44, '2006-02-14 21:45:25'),
(567, 'Vicente Lpez', 6, '2006-02-14 21:45:25'),
(568, 'Vijayawada', 44, '2006-02-14 21:45:25'),
(569, 'Vila Velha', 15, '2006-02-14 21:45:25'),
(570, 'Vilnius', 56, '2006-02-14 21:45:25'),
(571, 'Vinh', 105, '2006-02-14 21:45:25'),
(572, 'Vitria de Santo Anto', 15, '2006-02-14 21:45:25'),
(573, 'Warren', 103, '2006-02-14 21:45:25'),
(574, 'Weifang', 23, '2006-02-14 21:45:25'),
(575, 'Witten', 38, '2006-02-14 21:45:25'),
(576, 'Woodridge', 8, '2006-02-14 21:45:25'),
(577, 'Wroclaw', 76, '2006-02-14 21:45:25'),
(578, 'Xiangfan', 23, '2006-02-14 21:45:25'),
(579, 'Xiangtan', 23, '2006-02-14 21:45:25'),
(580, 'Xintai', 23, '2006-02-14 21:45:25'),
(581, 'Xinxiang', 23, '2006-02-14 21:45:25'),
(582, 'Yamuna Nagar', 44, '2006-02-14 21:45:25'),
(583, 'Yangor', 65, '2006-02-14 21:45:25'),
(584, 'Yantai', 23, '2006-02-14 21:45:25'),
(585, 'Yaound', 19, '2006-02-14 21:45:25'),
(586, 'Yerevan', 7, '2006-02-14 21:45:25'),
(587, 'Yinchuan', 23, '2006-02-14 21:45:25'),
(588, 'Yingkou', 23, '2006-02-14 21:45:25'),
(589, 'York', 102, '2006-02-14 21:45:25'),
(590, 'Yuncheng', 23, '2006-02-14 21:45:25'),
(591, 'Yuzhou', 23, '2006-02-14 21:45:25'),
(592, 'Zalantun', 23, '2006-02-14 21:45:25'),
(593, 'Zanzibar', 93, '2006-02-14 21:45:25'),
(594, 'Zaoyang', 23, '2006-02-14 21:45:25'),
(595, 'Zapopan', 60, '2006-02-14 21:45:25'),
(596, 'Zaria', 69, '2006-02-14 21:45:25'),
(597, 'Zeleznogorsk', 80, '2006-02-14 21:45:25'),
(598, 'Zhezqazghan', 51, '2006-02-14 21:45:25'),
(599, 'Zhoushan', 23, '2006-02-14 21:45:25'),
(600, 'Ziguinchor', 83, '2006-02-14 21:45:25');

-- --------------------------------------------------------

--
-- Struktur dari tabel `country`
--

CREATE TABLE `country` (
  `country_id` smallint(5) UNSIGNED NOT NULL,
  `country` varchar(50) NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

--
-- Dumping data untuk tabel `country`
--

INSERT INTO `country` (`country_id`, `country`, `last_update`) VALUES
(1, 'Afghanistan', '2006-02-14 21:44:00'),
(2, 'Algeria', '2006-02-14 21:44:00'),
(3, 'American Samoa', '2006-02-14 21:44:00'),
(4, 'Angola', '2006-02-14 21:44:00'),
(5, 'Anguilla', '2006-02-14 21:44:00'),
(6, 'Argentina', '2006-02-14 21:44:00'),
(7, 'Armenia', '2006-02-14 21:44:00'),
(8, 'Australia', '2006-02-14 21:44:00'),
(9, 'Austria', '2006-02-14 21:44:00'),
(10, 'Azerbaijan', '2006-02-14 21:44:00'),
(11, 'Bahrain', '2006-02-14 21:44:00'),
(12, 'Bangladesh', '2006-02-14 21:44:00'),
(13, 'Belarus', '2006-02-14 21:44:00'),
(14, 'Bolivia', '2006-02-14 21:44:00'),
(15, 'Brazil', '2006-02-14 21:44:00'),
(16, 'Brunei', '2006-02-14 21:44:00'),
(17, 'Bulgaria', '2006-02-14 21:44:00'),
(18, 'Cambodia', '2006-02-14 21:44:00'),
(19, 'Cameroon', '2006-02-14 21:44:00'),
(20, 'Canada', '2006-02-14 21:44:00'),
(21, 'Chad', '2006-02-14 21:44:00'),
(22, 'Chile', '2006-02-14 21:44:00'),
(23, 'China', '2006-02-14 21:44:00'),
(24, 'Colombia', '2006-02-14 21:44:00'),
(25, 'Congo, The Democratic Republic of the', '2006-02-14 21:44:00'),
(26, 'Czech Republic', '2006-02-14 21:44:00'),
(27, 'Dominican Republic', '2006-02-14 21:44:00'),
(28, 'Ecuador', '2006-02-14 21:44:00'),
(29, 'Egypt', '2006-02-14 21:44:00'),
(30, 'Estonia', '2006-02-14 21:44:00'),
(31, 'Ethiopia', '2006-02-14 21:44:00'),
(32, 'Faroe Islands', '2006-02-14 21:44:00'),
(33, 'Finland', '2006-02-14 21:44:00'),
(34, 'France', '2006-02-14 21:44:00'),
(35, 'French Guiana', '2006-02-14 21:44:00'),
(36, 'French Polynesia', '2006-02-14 21:44:00'),
(37, 'Gambia', '2006-02-14 21:44:00'),
(38, 'Germany', '2006-02-14 21:44:00'),
(39, 'Greece', '2006-02-14 21:44:00'),
(40, 'Greenland', '2006-02-14 21:44:00'),
(41, 'Holy See (Vatican City State)', '2006-02-14 21:44:00'),
(42, 'Hong Kong', '2006-02-14 21:44:00'),
(43, 'Hungary', '2006-02-14 21:44:00'),
(44, 'India', '2006-02-14 21:44:00'),
(45, 'Indonesia', '2006-02-14 21:44:00'),
(46, 'Iran', '2006-02-14 21:44:00'),
(47, 'Iraq', '2006-02-14 21:44:00'),
(48, 'Israel', '2006-02-14 21:44:00'),
(49, 'Italy', '2006-02-14 21:44:00'),
(50, 'Japan', '2006-02-14 21:44:00'),
(51, 'Kazakstan', '2006-02-14 21:44:00'),
(52, 'Kenya', '2006-02-14 21:44:00'),
(53, 'Kuwait', '2006-02-14 21:44:00'),
(54, 'Latvia', '2006-02-14 21:44:00'),
(55, 'Liechtenstein', '2006-02-14 21:44:00'),
(56, 'Lithuania', '2006-02-14 21:44:00'),
(57, 'Madagascar', '2006-02-14 21:44:00'),
(58, 'Malawi', '2006-02-14 21:44:00'),
(59, 'Malaysia', '2006-02-14 21:44:00'),
(60, 'Mexico', '2006-02-14 21:44:00'),
(61, 'Moldova', '2006-02-14 21:44:00'),
(62, 'Morocco', '2006-02-14 21:44:00'),
(63, 'Mozambique', '2006-02-14 21:44:00'),
(64, 'Myanmar', '2006-02-14 21:44:00'),
(65, 'Nauru', '2006-02-14 21:44:00'),
(66, 'Nepal', '2006-02-14 21:44:00'),
(67, 'Netherlands', '2006-02-14 21:44:00'),
(68, 'New Zealand', '2006-02-14 21:44:00'),
(69, 'Nigeria', '2006-02-14 21:44:00'),
(70, 'North Korea', '2006-02-14 21:44:00'),
(71, 'Oman', '2006-02-14 21:44:00'),
(72, 'Pakistan', '2006-02-14 21:44:00'),
(73, 'Paraguay', '2006-02-14 21:44:00'),
(74, 'Peru', '2006-02-14 21:44:00'),
(75, 'Philippines', '2006-02-14 21:44:00'),
(76, 'Poland', '2006-02-14 21:44:00'),
(77, 'Puerto Rico', '2006-02-14 21:44:00'),
(78, 'Romania', '2006-02-14 21:44:00'),
(79, 'Runion', '2006-02-14 21:44:00'),
(80, 'Russian Federation', '2006-02-14 21:44:00'),
(81, 'Saint Vincent and the Grenadines', '2006-02-14 21:44:00'),
(82, 'Saudi Arabia', '2006-02-14 21:44:00'),
(83, 'Senegal', '2006-02-14 21:44:00'),
(84, 'Slovakia', '2006-02-14 21:44:00'),
(85, 'South Africa', '2006-02-14 21:44:00'),
(86, 'South Korea', '2006-02-14 21:44:00'),
(87, 'Spain', '2006-02-14 21:44:00'),
(88, 'Sri Lanka', '2006-02-14 21:44:00'),
(89, 'Sudan', '2006-02-14 21:44:00'),
(90, 'Sweden', '2006-02-14 21:44:00'),
(91, 'Switzerland', '2006-02-14 21:44:00'),
(92, 'Taiwan', '2006-02-14 21:44:00'),
(93, 'Tanzania', '2006-02-14 21:44:00'),
(94, 'Thailand', '2006-02-14 21:44:00'),
(95, 'Tonga', '2006-02-14 21:44:00'),
(96, 'Tunisia', '2006-02-14 21:44:00'),
(97, 'Turkey', '2006-02-14 21:44:00'),
(98, 'Turkmenistan', '2006-02-14 21:44:00'),
(99, 'Tuvalu', '2006-02-14 21:44:00'),
(100, 'Ukraine', '2006-02-14 21:44:00'),
(101, 'United Arab Emirates', '2006-02-14 21:44:00'),
(102, 'United Kingdom', '2006-02-14 21:44:00'),
(103, 'United States', '2006-02-14 21:44:00'),
(104, 'Venezuela', '2006-02-14 21:44:00'),
(105, 'Vietnam', '2006-02-14 21:44:00'),
(106, 'Virgin Islands, U.S.', '2006-02-14 21:44:00'),
(107, 'Yemen', '2006-02-14 21:44:00'),
(108, 'Yugoslavia', '2006-02-14 21:44:00'),
(109, 'Zambia', '2006-02-14 21:44:00');

-- --------------------------------------------------------

--
-- Struktur dari tabel `customer`
--

CREATE TABLE `customer` (
  `customer_id` smallint(5) UNSIGNED NOT NULL,
  `store_id` tinyint(3) UNSIGNED NOT NULL,
  `first_name` varchar(45) NOT NULL,
  `last_name` varchar(45) NOT NULL,
  `email` varchar(50) DEFAULT NULL,
  `address_id` smallint(5) UNSIGNED NOT NULL,
  `active` tinyint(1) NOT NULL DEFAULT '1',
  `create_date` datetime NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `customer_list`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `customer_list` (
`ID` smallint(5) unsigned
,`name` varchar(91)
,`address` varchar(50)
,`zip code` varchar(10)
,`phone` varchar(20)
,`city` varchar(50)
,`country` varchar(50)
,`notes` varchar(6)
,`SID` tinyint(3) unsigned
);

-- --------------------------------------------------------

--
-- Struktur dari tabel `film`
--

CREATE TABLE `film` (
  `film_id` smallint(5) UNSIGNED NOT NULL,
  `title` varchar(128) NOT NULL,
  `description` text,
  `release_year` year(4) DEFAULT NULL,
  `language_id` tinyint(3) UNSIGNED NOT NULL,
  `original_language_id` tinyint(3) UNSIGNED DEFAULT NULL,
  `rental_duration` tinyint(3) UNSIGNED NOT NULL DEFAULT '3',
  `rental_rate` decimal(4,2) NOT NULL DEFAULT '4.99',
  `length` smallint(5) UNSIGNED DEFAULT NULL,
  `replacement_cost` decimal(5,2) NOT NULL DEFAULT '19.99',
  `rating` enum('G','PG','PG-13','R','NC-17') DEFAULT 'G',
  `special_features` set('Trailers','Commentaries','Deleted Scenes','Behind the Scenes') DEFAULT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

--
-- Trigger `film`
--
DELIMITER $$
CREATE TRIGGER `del_film` AFTER DELETE ON `film` FOR EACH ROW BEGIN
    DELETE FROM film_text WHERE film_id = old.film_id;
  END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `ins_film` AFTER INSERT ON `film` FOR EACH ROW BEGIN
    INSERT INTO film_text (film_id, title, description)
        VALUES (new.film_id, new.title, new.description);
  END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `upd_film` AFTER UPDATE ON `film` FOR EACH ROW BEGIN
    IF (old.title != new.title) OR (old.description != new.description) OR (old.film_id != new.film_id)
    THEN
        UPDATE film_text
            SET title=new.title,
                description=new.description,
                film_id=new.film_id
        WHERE film_id=old.film_id;
    END IF;
  END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Struktur dari tabel `film_actor`
--

CREATE TABLE `film_actor` (
  `actor_id` smallint(5) UNSIGNED NOT NULL,
  `film_id` smallint(5) UNSIGNED NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Struktur dari tabel `film_category`
--

CREATE TABLE `film_category` (
  `film_id` smallint(5) UNSIGNED NOT NULL,
  `category_id` tinyint(3) UNSIGNED NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `film_list`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `film_list` (
`FID` smallint(5) unsigned
,`title` varchar(128)
,`description` text
,`category` varchar(25)
,`price` decimal(4,2)
,`length` smallint(5) unsigned
,`rating` enum('G','PG','PG-13','R','NC-17')
,`actors` text
);

-- --------------------------------------------------------

--
-- Struktur dari tabel `film_text`
--

CREATE TABLE `film_text` (
  `film_id` smallint(6) NOT NULL,
  `title` varchar(255) NOT NULL,
  `description` text
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Struktur dari tabel `inventory`
--

CREATE TABLE `inventory` (
  `inventory_id` mediumint(8) UNSIGNED NOT NULL,
  `film_id` smallint(5) UNSIGNED NOT NULL,
  `store_id` tinyint(3) UNSIGNED NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Struktur dari tabel `language`
--

CREATE TABLE `language` (
  `language_id` tinyint(3) UNSIGNED NOT NULL,
  `name` char(20) NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

--
-- Dumping data untuk tabel `language`
--

INSERT INTO `language` (`language_id`, `name`, `last_update`) VALUES
(1, 'English', '2006-02-14 22:02:19'),
(2, 'Italian', '2006-02-14 22:02:19'),
(3, 'Japanese', '2006-02-14 22:02:19'),
(4, 'Mandarin', '2006-02-14 22:02:19'),
(5, 'French', '2006-02-14 22:02:19'),
(6, 'German', '2006-02-14 22:02:19');

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `nicer_but_slower_film_list`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `nicer_but_slower_film_list` (
`FID` smallint(5) unsigned
,`title` varchar(128)
,`description` text
,`category` varchar(25)
,`price` decimal(4,2)
,`length` smallint(5) unsigned
,`rating` enum('G','PG','PG-13','R','NC-17')
,`actors` text
);

-- --------------------------------------------------------

--
-- Struktur dari tabel `payment`
--

CREATE TABLE `payment` (
  `payment_id` smallint(5) UNSIGNED NOT NULL,
  `customer_id` smallint(5) UNSIGNED NOT NULL,
  `staff_id` tinyint(3) UNSIGNED NOT NULL,
  `rental_id` int(11) DEFAULT NULL,
  `amount` decimal(5,2) NOT NULL,
  `payment_date` datetime NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Struktur dari tabel `rental`
--

CREATE TABLE `rental` (
  `rental_id` int(11) NOT NULL,
  `rental_date` datetime NOT NULL,
  `inventory_id` mediumint(8) UNSIGNED NOT NULL,
  `customer_id` smallint(5) UNSIGNED NOT NULL,
  `return_date` datetime DEFAULT NULL,
  `staff_id` tinyint(3) UNSIGNED NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `sales_by_film_category`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `sales_by_film_category` (
`category` varchar(25)
,`total_sales` decimal(27,2)
);

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `sales_by_store`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `sales_by_store` (
`store` varchar(101)
,`manager` varchar(91)
,`total_sales` decimal(27,2)
);

-- --------------------------------------------------------

--
-- Struktur dari tabel `staff`
--

CREATE TABLE `staff` (
  `staff_id` tinyint(3) UNSIGNED NOT NULL,
  `first_name` varchar(45) NOT NULL,
  `last_name` varchar(45) NOT NULL,
  `address_id` smallint(5) UNSIGNED NOT NULL,
  `picture` blob,
  `email` varchar(50) DEFAULT NULL,
  `store_id` tinyint(3) UNSIGNED NOT NULL,
  `active` tinyint(1) NOT NULL DEFAULT '1',
  `username` varchar(16) NOT NULL,
  `password` varchar(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Stand-in struktur untuk tampilan `staff_list`
-- (Lihat di bawah untuk tampilan aktual)
--
CREATE TABLE `staff_list` (
`ID` tinyint(3) unsigned
,`name` varchar(91)
,`address` varchar(50)
,`zip code` varchar(10)
,`phone` varchar(20)
,`city` varchar(50)
,`country` varchar(50)
,`SID` tinyint(3) unsigned
);

-- --------------------------------------------------------

--
-- Struktur dari tabel `store`
--

CREATE TABLE `store` (
  `store_id` tinyint(3) UNSIGNED NOT NULL,
  `manager_staff_id` tinyint(3) UNSIGNED NOT NULL,
  `address_id` smallint(5) UNSIGNED NOT NULL,
  `last_update` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- --------------------------------------------------------

--
-- Struktur untuk view `actor_info`
--
DROP TABLE IF EXISTS `actor_info`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY INVOKER VIEW `actor_info`  AS  select `a`.`actor_id` AS `actor_id`,`a`.`first_name` AS `first_name`,`a`.`last_name` AS `last_name`,group_concat(distinct concat(`c`.`name`,': ',(select group_concat(`f`.`title` order by `f`.`title` ASC separator ', ') from ((`film` `f` join `film_category` `fc` on((`f`.`film_id` = `fc`.`film_id`))) join `film_actor` `fa` on((`f`.`film_id` = `fa`.`film_id`))) where ((`fc`.`category_id` = `c`.`category_id`) and (`fa`.`actor_id` = `a`.`actor_id`)))) order by `c`.`name` ASC separator '; ') AS `film_info` from (((`actor` `a` left join `film_actor` `fa` on((`a`.`actor_id` = `fa`.`actor_id`))) left join `film_category` `fc` on((`fa`.`film_id` = `fc`.`film_id`))) left join `category` `c` on((`fc`.`category_id` = `c`.`category_id`))) group by `a`.`actor_id`,`a`.`first_name`,`a`.`last_name` ;

-- --------------------------------------------------------

--
-- Struktur untuk view `customer_list`
--
DROP TABLE IF EXISTS `customer_list`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `customer_list`  AS  select `cu`.`customer_id` AS `ID`,concat(`cu`.`first_name`,_utf8mb4' ',`cu`.`last_name`) AS `name`,`a`.`address` AS `address`,`a`.`postal_code` AS `zip code`,`a`.`phone` AS `phone`,`city`.`city` AS `city`,`country`.`country` AS `country`,if(`cu`.`active`,_utf8mb4'active',_utf8mb4'') AS `notes`,`cu`.`store_id` AS `SID` from (((`customer` `cu` join `address` `a` on((`cu`.`address_id` = `a`.`address_id`))) join `city` on((`a`.`city_id` = `city`.`city_id`))) join `country` on((`city`.`country_id` = `country`.`country_id`))) ;

-- --------------------------------------------------------

--
-- Struktur untuk view `film_list`
--
DROP TABLE IF EXISTS `film_list`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `film_list`  AS  select `film`.`film_id` AS `FID`,`film`.`title` AS `title`,`film`.`description` AS `description`,`category`.`name` AS `category`,`film`.`rental_rate` AS `price`,`film`.`length` AS `length`,`film`.`rating` AS `rating`,group_concat(concat(`actor`.`first_name`,_utf8mb4' ',`actor`.`last_name`) separator ', ') AS `actors` from ((((`category` left join `film_category` on((`category`.`category_id` = `film_category`.`category_id`))) left join `film` on((`film_category`.`film_id` = `film`.`film_id`))) join `film_actor` on((`film`.`film_id` = `film_actor`.`film_id`))) join `actor` on((`film_actor`.`actor_id` = `actor`.`actor_id`))) group by `film`.`film_id`,`category`.`name` ;

-- --------------------------------------------------------

--
-- Struktur untuk view `nicer_but_slower_film_list`
--
DROP TABLE IF EXISTS `nicer_but_slower_film_list`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `nicer_but_slower_film_list`  AS  select `film`.`film_id` AS `FID`,`film`.`title` AS `title`,`film`.`description` AS `description`,`category`.`name` AS `category`,`film`.`rental_rate` AS `price`,`film`.`length` AS `length`,`film`.`rating` AS `rating`,group_concat(concat(concat(ucase(substr(`actor`.`first_name`,1,1)),lcase(substr(`actor`.`first_name`,2,length(`actor`.`first_name`))),_utf8mb4' ',concat(ucase(substr(`actor`.`last_name`,1,1)),lcase(substr(`actor`.`last_name`,2,length(`actor`.`last_name`)))))) separator ', ') AS `actors` from ((((`category` left join `film_category` on((`category`.`category_id` = `film_category`.`category_id`))) left join `film` on((`film_category`.`film_id` = `film`.`film_id`))) join `film_actor` on((`film`.`film_id` = `film_actor`.`film_id`))) join `actor` on((`film_actor`.`actor_id` = `actor`.`actor_id`))) group by `film`.`film_id`,`category`.`name` ;

-- --------------------------------------------------------

--
-- Struktur untuk view `sales_by_film_category`
--
DROP TABLE IF EXISTS `sales_by_film_category`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `sales_by_film_category`  AS  select `c`.`name` AS `category`,sum(`p`.`amount`) AS `total_sales` from (((((`payment` `p` join `rental` `r` on((`p`.`rental_id` = `r`.`rental_id`))) join `inventory` `i` on((`r`.`inventory_id` = `i`.`inventory_id`))) join `film` `f` on((`i`.`film_id` = `f`.`film_id`))) join `film_category` `fc` on((`f`.`film_id` = `fc`.`film_id`))) join `category` `c` on((`fc`.`category_id` = `c`.`category_id`))) group by `c`.`name` order by sum(`p`.`amount`) desc ;

-- --------------------------------------------------------

--
-- Struktur untuk view `sales_by_store`
--
DROP TABLE IF EXISTS `sales_by_store`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `sales_by_store`  AS  select concat(`c`.`city`,_utf8mb4',',`cy`.`country`) AS `store`,concat(`m`.`first_name`,_utf8mb4' ',`m`.`last_name`) AS `manager`,sum(`p`.`amount`) AS `total_sales` from (((((((`payment` `p` join `rental` `r` on((`p`.`rental_id` = `r`.`rental_id`))) join `inventory` `i` on((`r`.`inventory_id` = `i`.`inventory_id`))) join `store` `s` on((`i`.`store_id` = `s`.`store_id`))) join `address` `a` on((`s`.`address_id` = `a`.`address_id`))) join `city` `c` on((`a`.`city_id` = `c`.`city_id`))) join `country` `cy` on((`c`.`country_id` = `cy`.`country_id`))) join `staff` `m` on((`s`.`manager_staff_id` = `m`.`staff_id`))) group by `s`.`store_id` order by `cy`.`country`,`c`.`city` ;

-- --------------------------------------------------------

--
-- Struktur untuk view `staff_list`
--
DROP TABLE IF EXISTS `staff_list`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `staff_list`  AS  select `s`.`staff_id` AS `ID`,concat(`s`.`first_name`,_utf8mb4' ',`s`.`last_name`) AS `name`,`a`.`address` AS `address`,`a`.`postal_code` AS `zip code`,`a`.`phone` AS `phone`,`city`.`city` AS `city`,`country`.`country` AS `country`,`s`.`store_id` AS `SID` from (((`staff` `s` join `address` `a` on((`s`.`address_id` = `a`.`address_id`))) join `city` on((`a`.`city_id` = `city`.`city_id`))) join `country` on((`city`.`country_id` = `country`.`country_id`))) ;

--
-- Indexes for dumped tables
--

--
-- Indeks untuk tabel `actor`
--
ALTER TABLE `actor`
  ADD PRIMARY KEY (`actor_id`),
  ADD KEY `idx_actor_last_name` (`last_name`);

--
-- Indeks untuk tabel `address`
--
ALTER TABLE `address`
  ADD PRIMARY KEY (`address_id`),
  ADD KEY `idx_fk_city_id` (`city_id`);

--
-- Indeks untuk tabel `category`
--
ALTER TABLE `category`
  ADD PRIMARY KEY (`category_id`);

--
-- Indeks untuk tabel `city`
--
ALTER TABLE `city`
  ADD PRIMARY KEY (`city_id`),
  ADD KEY `idx_fk_country_id` (`country_id`);

--
-- Indeks untuk tabel `country`
--
ALTER TABLE `country`
  ADD PRIMARY KEY (`country_id`);

--
-- Indeks untuk tabel `customer`
--
ALTER TABLE `customer`
  ADD PRIMARY KEY (`customer_id`),
  ADD KEY `idx_fk_store_id` (`store_id`),
  ADD KEY `idx_fk_address_id` (`address_id`),
  ADD KEY `idx_last_name` (`last_name`);

--
-- Indeks untuk tabel `film`
--
ALTER TABLE `film`
  ADD PRIMARY KEY (`film_id`),
  ADD KEY `idx_title` (`title`),
  ADD KEY `idx_fk_language_id` (`language_id`),
  ADD KEY `idx_fk_original_language_id` (`original_language_id`);

--
-- Indeks untuk tabel `film_actor`
--
ALTER TABLE `film_actor`
  ADD PRIMARY KEY (`actor_id`,`film_id`),
  ADD KEY `idx_fk_film_id` (`film_id`);

--
-- Indeks untuk tabel `film_category`
--
ALTER TABLE `film_category`
  ADD PRIMARY KEY (`film_id`,`category_id`),
  ADD KEY `fk_film_category_category` (`category_id`);

--
-- Indeks untuk tabel `film_text`
--
ALTER TABLE `film_text`
  ADD PRIMARY KEY (`film_id`);
ALTER TABLE `film_text` ADD FULLTEXT KEY `idx_title_description` (`title`,`description`);

--
-- Indeks untuk tabel `inventory`
--
ALTER TABLE `inventory`
  ADD PRIMARY KEY (`inventory_id`),
  ADD KEY `idx_fk_film_id` (`film_id`),
  ADD KEY `idx_store_id_film_id` (`store_id`,`film_id`);

--
-- Indeks untuk tabel `language`
--
ALTER TABLE `language`
  ADD PRIMARY KEY (`language_id`);

--
-- Indeks untuk tabel `payment`
--
ALTER TABLE `payment`
  ADD PRIMARY KEY (`payment_id`),
  ADD KEY `idx_fk_staff_id` (`staff_id`),
  ADD KEY `idx_fk_customer_id` (`customer_id`),
  ADD KEY `fk_payment_rental` (`rental_id`);

--
-- Indeks untuk tabel `rental`
--
ALTER TABLE `rental`
  ADD PRIMARY KEY (`rental_id`),
  ADD UNIQUE KEY `rental_date` (`rental_date`,`inventory_id`,`customer_id`),
  ADD KEY `idx_fk_inventory_id` (`inventory_id`),
  ADD KEY `idx_fk_customer_id` (`customer_id`),
  ADD KEY `idx_fk_staff_id` (`staff_id`);

--
-- Indeks untuk tabel `staff`
--
ALTER TABLE `staff`
  ADD PRIMARY KEY (`staff_id`),
  ADD KEY `idx_fk_store_id` (`store_id`),
  ADD KEY `idx_fk_address_id` (`address_id`);

--
-- Indeks untuk tabel `store`
--
ALTER TABLE `store`
  ADD PRIMARY KEY (`store_id`),
  ADD UNIQUE KEY `idx_unique_manager` (`manager_staff_id`),
  ADD KEY `idx_fk_address_id` (`address_id`);

--
-- AUTO_INCREMENT untuk tabel yang dibuang
--

--
-- AUTO_INCREMENT untuk tabel `actor`
--
ALTER TABLE `actor`
  MODIFY `actor_id` smallint(5) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=201;

--
-- AUTO_INCREMENT untuk tabel `address`
--
ALTER TABLE `address`
  MODIFY `address_id` smallint(5) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `category`
--
ALTER TABLE `category`
  MODIFY `category_id` tinyint(3) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=17;

--
-- AUTO_INCREMENT untuk tabel `city`
--
ALTER TABLE `city`
  MODIFY `city_id` smallint(5) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=601;

--
-- AUTO_INCREMENT untuk tabel `country`
--
ALTER TABLE `country`
  MODIFY `country_id` smallint(5) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=110;

--
-- AUTO_INCREMENT untuk tabel `customer`
--
ALTER TABLE `customer`
  MODIFY `customer_id` smallint(5) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `film`
--
ALTER TABLE `film`
  MODIFY `film_id` smallint(5) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `inventory`
--
ALTER TABLE `inventory`
  MODIFY `inventory_id` mediumint(8) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `language`
--
ALTER TABLE `language`
  MODIFY `language_id` tinyint(3) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=7;

--
-- AUTO_INCREMENT untuk tabel `payment`
--
ALTER TABLE `payment`
  MODIFY `payment_id` smallint(5) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `rental`
--
ALTER TABLE `rental`
  MODIFY `rental_id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `staff`
--
ALTER TABLE `staff`
  MODIFY `staff_id` tinyint(3) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT untuk tabel `store`
--
ALTER TABLE `store`
  MODIFY `store_id` tinyint(3) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- Ketidakleluasaan untuk tabel pelimpahan (Dumped Tables)
--

--
-- Ketidakleluasaan untuk tabel `address`
--
ALTER TABLE `address`
  ADD CONSTRAINT `fk_address_city` FOREIGN KEY (`city_id`) REFERENCES `city` (`city_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `city`
--
ALTER TABLE `city`
  ADD CONSTRAINT `fk_city_country` FOREIGN KEY (`country_id`) REFERENCES `country` (`country_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `customer`
--
ALTER TABLE `customer`
  ADD CONSTRAINT `fk_customer_address` FOREIGN KEY (`address_id`) REFERENCES `address` (`address_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_customer_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`store_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `film`
--
ALTER TABLE `film`
  ADD CONSTRAINT `fk_film_language` FOREIGN KEY (`language_id`) REFERENCES `language` (`language_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_film_language_original` FOREIGN KEY (`original_language_id`) REFERENCES `language` (`language_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `film_actor`
--
ALTER TABLE `film_actor`
  ADD CONSTRAINT `fk_film_actor_actor` FOREIGN KEY (`actor_id`) REFERENCES `actor` (`actor_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_film_actor_film` FOREIGN KEY (`film_id`) REFERENCES `film` (`film_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `film_category`
--
ALTER TABLE `film_category`
  ADD CONSTRAINT `fk_film_category_category` FOREIGN KEY (`category_id`) REFERENCES `category` (`category_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_film_category_film` FOREIGN KEY (`film_id`) REFERENCES `film` (`film_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `inventory`
--
ALTER TABLE `inventory`
  ADD CONSTRAINT `fk_inventory_film` FOREIGN KEY (`film_id`) REFERENCES `film` (`film_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_inventory_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`store_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `payment`
--
ALTER TABLE `payment`
  ADD CONSTRAINT `fk_payment_customer` FOREIGN KEY (`customer_id`) REFERENCES `customer` (`customer_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_payment_rental` FOREIGN KEY (`rental_id`) REFERENCES `rental` (`rental_id`) ON DELETE SET NULL ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_payment_staff` FOREIGN KEY (`staff_id`) REFERENCES `staff` (`staff_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `rental`
--
ALTER TABLE `rental`
  ADD CONSTRAINT `fk_rental_customer` FOREIGN KEY (`customer_id`) REFERENCES `customer` (`customer_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_rental_inventory` FOREIGN KEY (`inventory_id`) REFERENCES `inventory` (`inventory_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_rental_staff` FOREIGN KEY (`staff_id`) REFERENCES `staff` (`staff_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `staff`
--
ALTER TABLE `staff`
  ADD CONSTRAINT `fk_staff_address` FOREIGN KEY (`address_id`) REFERENCES `address` (`address_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_staff_store` FOREIGN KEY (`store_id`) REFERENCES `store` (`store_id`) ON UPDATE CASCADE;

--
-- Ketidakleluasaan untuk tabel `store`
--
ALTER TABLE `store`
  ADD CONSTRAINT `fk_store_address` FOREIGN KEY (`address_id`) REFERENCES `address` (`address_id`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_store_staff` FOREIGN KEY (`manager_staff_id`) REFERENCES `staff` (`staff_id`) ON UPDATE CASCADE;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
